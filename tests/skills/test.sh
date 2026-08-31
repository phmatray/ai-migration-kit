#!/usr/bin/env bash
# Golden test for check-frontmatter.py.
#
# That checker is an ABSENCE rule: it asserts skill frontmatter carries no `version`
# key (#16). An absence rule has no positive witness in the repo — the six real skills
# already satisfy it — so a pattern that quietly stops matching keeps printing
# "frontmatter OK" and CI cannot tell. Typo the key to `versionn`, drop a spelling,
# narrow the check out of existence: all stay green. This file is that missing witness.
#
# It also pins the two bugs the #16 review found in the first, regex-based attempt:
#   - `^[ \t]*version:` also matched indented continuation lines of a `>-` block
#     scalar, so PROSE tripped the guard (false positive, cases N2/N3 below);
#   - it missed `"version":`, `'version':`, `version :` and the flow form
#     `metadata: {version: 1}`, all the same key to YAML (false negatives, P2–P5).
# Both are why the checker parses YAML instead of pattern-matching.
set -euo pipefail
cd "$(dirname "$0")/../.."

CHECK="tests/skills/check-frontmatter.py"
[ -f "$CHECK" ] || { echo "FAIL: $CHECK missing"; exit 1; }

# Scratch dir and EXIT trap come from the shared preamble (#72) — eight suites each had
# their own, and they had diverged. KIT_ROOT is derived from this file's location rather
# than $PWD: $PWD is only right because a `cd` sits above, and moving it would break the
# source silently (tests/ci-wiring did exactly that).
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
WORK=$(kit_scratch)

# check-frontmatter.py resolves its root as parents[2] of its own path, so a scratch
# tree holding skills/, tests/skills/ and requirements.json is a complete world.
mkdir -p "$WORK/root"
# commands/ joins the scratch world for #266: commands/auto-dev-worker.md is a declared consumer of
# the untrusted-input boundary (it is what a dispatched worker actually reads), so a root without it
# answers NO SUCH CONSUMER for every boundary case below. It is never mutated — only skills/ is
# restored between cases — so one copy at setup is enough.
cp -R skills tests commands requirements.json "$WORK/root/"
ROOT="$WORK/root"
PRISTINE="$WORK/pristine"
mkdir -p "$PRISTINE"
cp -R "$ROOT/skills" "$PRISTINE/"

fails=0

# run_case <label> <expect: pass|fail> <python mutator>
# The mutator receives the scratch root as argv[1] and edits a SKILL.md in place.
run_case() {
  local label="$1" expect="$2" mutator="$3"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc
  set +e
  out=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1)
  rc=$?
  set -e
  if [ "$expect" = fail ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: [$label] expected a rejection, got exit 0"
      echo "      $out"
      fails=$((fails + 1))
    elif ! grep -q 'forbidden (#16)\|missing' <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with the expected message"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] rejected"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      echo "FAIL: [$label] expected acceptance, got exit $rc"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] accepted"
    fi
  fi
}

# Replace the `metadata:` block of one skill with an arbitrary YAML snippet.
meta_mutator() {
  cat <<PY
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r'^metadata:\n(?:[ \t]+.*\n)+', '''$1''', t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
PY
}

echo "== a version key must be rejected, however it is spelled =="
run_case "P1 plain           metadata.version" fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: ai-migration-kit
  version: 1.8.0
')"
run_case "P2 double-quoted   metadata.version" fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: ai-migration-kit
  "version": 1.8.0
')"
run_case "P3 single-quoted   metadata.version" fail "$(meta_mutator "metadata:
  author: Philippe Matray
  suite: ai-migration-kit
  'version': 1.8.0
")"
run_case "P4 space-before-colon             " fail "$(meta_mutator 'metadata:
  author: Philippe Matray
  suite: ai-migration-kit
  version : 1.8.0
')"
run_case "P5 flow mapping    metadata.version" fail "$(meta_mutator 'metadata: {author: Philippe Matray, suite: ai-migration-kit, version: 1.8.0}
')"
run_case "P6 top-level       version         " fail "$(meta_mutator 'version: 2.0.0
metadata:
  author: Philippe Matray
  suite: ai-migration-kit
')"

echo "== the other frontmatter facts stay enforced =="
run_case "P7 metadata.author missing        " fail "$(meta_mutator 'metadata:
  suite: ai-migration-kit
')"
run_case "P8 metadata.suite missing         " fail "$(meta_mutator 'metadata:
  author: Philippe Matray
')"
run_case "P9 license key missing            " fail '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/followups/SKILL.md"
t = p.read_text(encoding="utf-8")
# Drop the key but leave the WORD in prose: a substring test would still pass here.
t = t.replace("license: MIT\n", "", 1)
t = t.replace("compatibility: >-", "compatibility: >-\n  Ships under an MIT license: see LICENSE.", 1)
p.write_text(t, encoding="utf-8")
'

echo "== prose is not a key: these must be accepted =="
run_case "N1 untouched baseline             " pass 'import sys'
run_case "N2 \"version:\" inside compatibility" pass '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^compatibility: >-\n(?:[ \t]+.*\n)+",
           "compatibility: >-\n  Requires python3 and git. Tested against gh CLI at\n"
           "  version: 2.40 or later.\n", t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'
run_case "N3 \"version:\" inside description  " pass '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^description: >-\n(?:[ \t]+.*\n)+",
           "description: >-\n  Consolidates open migration follow-ups. Reports the schema\n"
           "  version: 2 payload. Triggers on \"what is still open\", « fais le point ».\n",
           t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "check-frontmatter golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# check-untrusted-boundary.py (#266) — the same ABSENCE-rule problem, in both directions.
#
# The real tree satisfies the guard by construction: five consumers, all linked, none unlisted.
# So its pass path proves nothing on its own — narrow a pattern, mistype the marker, or drop the
# rule-4 glob and it keeps printing "boundary OK" while enforcing less and less. These cases are
# the missing witness, one per refusal the checker claims to make.
#
# The reverse rule (UNLISTED LINKER) is the one that matters most here and the one no fixture-free
# run can ever exercise: it fires only when a file points at the boundary WITHOUT being declared,
# which by definition never happens in a tree that is passing. Without case B3 it could stop
# matching entirely and every CI run would still be green.
#
# Each of the six error markers gets its own case, and the two that mean "the inventory could not
# be read" additionally assert that UNLISTED LINKER is ABSENT. That second half is not padding: the
# first version of this checker answered a deleted boundary file with five "absent from ## Consumers
# in <the file that does not exist>" lines — a refusal contradicting itself — and a suite that only
# greps for the expected marker certifies that output as correct (#266 review).
echo "== the untrusted-input boundary must stay linked, in both directions (#266) =="

# run_boundary_case <label> <expect: pass|fail> <expected marker> <forbidden marker|""> <mutator>
# Same shape as run_case: restore skills/ from $PRISTINE, mutate, run the checker over $ROOT.
# tests/ is NOT restored between cases — only skills/ is mutated, exactly as above.
run_boundary_case() {
  local label="$1" expect="$2" marker="$3" forbidden="$4" mutator="$5"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc
  set +e
  out=$(python3 "$ROOT/tests/skills/check-untrusted-boundary.py" 2>&1)
  rc=$?
  set -e
  if [ "$expect" = fail ]; then
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: [$label] expected a rejection, got exit 0"
      echo "      $out"
      fails=$((fails + 1))
    elif ! grep -q "$marker" <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with '$marker'"
      echo "      $out"
      fails=$((fails + 1))
    elif [ -n "$forbidden" ] && grep -q "$forbidden" <<<"$out"; then
      echo "FAIL: [$label] rejected with '$marker', but also emitted '$forbidden'"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] rejected"
    fi
  else
    if [ "$rc" -ne 0 ]; then
      echo "FAIL: [$label] expected acceptance, got exit $rc"
      echo "      $out"
      fails=$((fails + 1))
    else
      echo "ok   [$label] accepted"
    fi
  fi
}

run_boundary_case "B1 consumer stops linking it      " fail "MISSING LINK:" "" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "skills/merge-pr/SKILL.md"
t = p.read_text(encoding="utf-8")
# Repoint every one of merge-pr’s links at a different shared reference — the realistic regression
# is a rewrite that keeps a link and loses this one, not a file that stops linking anything.
t = t.replace("](../_shared/untrusted-input-boundary.md)", "](../_shared/preconditions.md)")
p.write_text(t, encoding="utf-8")
'

run_boundary_case "B2 listed consumer disappears     " fail "NO SUCH CONSUMER:" "" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
t = t.replace("- `skills/create-issue/SKILL.md`", "- `skills/create-issue/SKILL-renamed.md`")
p.write_text(t, encoding="utf-8")
'

run_boundary_case "B3 a file links it unlisted       " fail "UNLISTED LINKER:" "" '
import pathlib, sys
# A THROWAWAY file, deliberately not a real skill: any real one is a plausible next consumer, and
# a fixture that hard-codes "this file must never be declared" turns red the day someone correctly
# declares it — a red build caused by closing the very reach gap the boundary exists for.
p = pathlib.Path(sys.argv[1]) / "skills/_shared/zz-unlisted-fixture.md"
p.write_text("Read it under [the boundary](./untrusted-input-boundary.md).\n", encoding="utf-8")
'

run_boundary_case "B4 a listed link is wrong-depth   " fail "BROKEN LINK:" "" '
import pathlib, sys
# The regression a substring test cannot see: every character of a correct link is present, and it
# resolves to skills/legacy-upgrade/_shared/… — a path that does not exist. The reminder reads
# fine and is unreachable, which is the guard emptied of meaning while looking green.
p = pathlib.Path(sys.argv[1]) / "skills/legacy-upgrade/references/phase-1-assess.md"
t = p.read_text(encoding="utf-8")
t = t.replace("](../../_shared/untrusted-input-boundary.md)", "](../_shared/untrusted-input-boundary.md)")
p.write_text(t, encoding="utf-8")
'

run_boundary_case "B5 the Consumers section is gone  " fail "NO CONSUMERS SECTION:" "UNLISTED LINKER:" '
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
# Split on the HEADING LINE, not the string: the doc cross-references `## Consumers` inline in its
# own intro, and a plain split truncates the file there instead — mutating something other than
# what the case name claims, which is how a fixture quietly stops testing its branch.
p.write_text(re.split(r"(?m)^## Consumers\s*$", t, maxsplit=1)[0], encoding="utf-8")
'

run_boundary_case "B6 the boundary file is deleted   " fail "NO BOUNDARY FILE:" "UNLISTED LINKER:" '
import pathlib, sys
(pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md").unlink()
'

run_boundary_case "B7 Consumers declared but empty   " fail "EMPTY CONSUMERS SECTION:" "" '
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
head = re.split(r"(?m)^## Consumers\s*$", t, maxsplit=1)[0]
p.write_text(head + "## Consumers\n\nNothing is declared here yet.\n", encoding="utf-8")
'

run_boundary_case "B8 a prose bullet is not a path   " pass "" "" '
import pathlib, sys
# The section is written for a human. A reflowed sentence must not become
# "NO SUCH CONSUMER: … lists (Anything)" — the checker verifies the claim, it does not dictate
# the punctuation the claim is written in.
p = pathlib.Path(sys.argv[1]) / "skills/_shared/untrusted-input-boundary.md"
t = p.read_text(encoding="utf-8")
p.write_text(t + "\n- Anything else that grows an ingest point belongs on this list.\n", encoding="utf-8")
'

run_boundary_case "B9 untouched baseline             " pass "" "" 'import sys'

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "check-untrusted-boundary golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The main-worktree derivation has one home now (#125): scripts/main-worktree.sh. Two broken
# spellings kept getting re-introduced before that — a caller resolving `-C` from
# `git rev-parse --show-toplevel` right next to a worktrees-ignored.sh call (fails OPEN from a
# linked worktree, tests/worktrees-ignored/test.sh case 22) and an `awk '{p=$2}'` listing that
# truncates a checkout under a path containing a space. This is the anti-recurrence guard: it
# scans the real skills/ tree, not a scratch copy, because the defect IS the committed prose and
# scripts, not something a fixture could stand in for.
#
# Proximity, not "the file mentions both": skills/get-repo-profile/scripts/repo-profile.sh
# legitimately carries an UNRELATED `rev-parse --show-toplevel` (line ~30, resolving the profile
# PATH argument — out of scope for #125, see the issue's own Assumptions) alongside four
# worktrees-ignored.sh mentions dozens of lines away. A whole-file substring check would flag that
# file forever; only a call sitting near a guard invocation is the actual bug.
echo "== the main-worktree derivation is not re-spelled (#125) =="
python3 - "$KIT_ROOT/skills" <<'PY'
import sys, pathlib

root = pathlib.Path(sys.argv[1])
REV_PARSE = "rev-parse --show-toplevel"
GUARD = "worktrees-ignored.sh"
AWK_BAD = "{p=$2}"
WINDOW = 5  # lines

failures = []
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        continue

    # Comment lines are explanatory prose, not re-introduced code — repo-profile.sh's own fix
    # comment says "this replaces `git rev-parse --show-toplevel`" a few lines above the guard
    # call it replaced it with, and that sentence is the point, not a regression.
    code_lines = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    rev_lines = [i for i, l in code_lines if REV_PARSE in l]
    guard_lines = [i for i, l in code_lines if GUARD in l]
    for r in rev_lines:
        for g in guard_lines:
            if abs(r - g) <= WINDOW:
                failures.append(
                    "%s: '%s' (line %d) sits next to a '%s' call (line %d) — "
                    "resolve the main checkout via scripts/main-worktree.sh instead (#125)"
                    % (path, REV_PARSE, r + 1, GUARD, g + 1)
                )
                break

    for i, l in enumerate(lines):
        if AWK_BAD in l and "worktree" in l:
            failures.append(
                "%s:%d: the truncating awk spelling ('{p=$2}') is back — a path containing a "
                "space would be cut at the first space (#125)" % (path, i + 1)
            )

if failures:
    print("FAIL: the main-worktree derivation was re-spelled:")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("ok   no file under skills/ re-spells the main-worktree derivation")
PY

# ---------------------------------------------------------------------------------------------
# CONTEXT.md (#313) — the kit's own domain glossary, in Matt Pocock's format (ported from
# mattpocock/skills, MIT). This is a structural case, not a content one: it proves the file
# stays in shape (a term section before the ambiguities section, every term actually defined,
# "decision" still flagged rather than quietly resolved by a rename) without pinning the prose
# itself, which is free to grow. It runs over the real committed file for the same reason the
# #125 scan above does — the defect this guards against is the committed file drifting out of
# its own format, not something a fixture could stand in for.
echo "== CONTEXT.md stays in Matt Pocock's format, with decision flagged (#313) =="
python3 - "$KIT_ROOT" <<'PY'
import re
import sys
import pathlib

root = pathlib.Path(sys.argv[1])
path = root / "CONTEXT.md"
if not path.is_file():
    print("FAIL: CONTEXT.md missing at the kit root")
    sys.exit(1)

lines = path.read_text(encoding="utf-8").splitlines()

# At least one `## ` section heading must precede `## Flagged ambiguities`.
amb_idx = next((i for i, l in enumerate(lines) if l.startswith("## Flagged ambiguities")), None)
if amb_idx is None:
    print("FAIL: CONTEXT.md has no '## Flagged ambiguities' section")
    sys.exit(1)
section_headings_before = [l for l in lines[:amb_idx] if l.startswith("## ")]
if not section_headings_before:
    print("FAIL: CONTEXT.md has no '## ' term section before '## Flagged ambiguities'")
    sys.exit(1)

# Every "**Term**:" line must be followed by a non-empty definition line — skipping over at most
# one blank line, since a term header, blank line, definition is still a valid layout.
term_re = re.compile(r"^\*\*[^*]+\*\*:\s*$")
for i, l in enumerate(lines):
    if term_re.match(l):
        j = i + 1
        if j < len(lines) and not lines[j].strip():
            j += 1
        nxt = lines[j] if j < len(lines) else ""
        if not nxt.strip() or term_re.match(nxt):
            print("FAIL: CONTEXT.md line %d ('%s') has no definition on the next line" % (i + 1, l))
            sys.exit(1)

# The ambiguities section must still name "decision" and its registry home, not resolve it away.
amb_text = "\n".join(lines[amb_idx:])
if "decision" not in amb_text:
    print("FAIL: CONTEXT.md's '## Flagged ambiguities' section does not mention \"decision\"")
    sys.exit(1)
if "docs/decisions.md" not in amb_text:
    print("FAIL: CONTEXT.md's '## Flagged ambiguities' section does not name docs/decisions.md")
    sys.exit(1)

print("ok   CONTEXT.md has term sections, defined terms, and decision flagged")
PY

# The two naming consumers must point at the target repo's CONTEXT.md, and say what they refuse.
echo "== create-issue and implement-issue read the target repo's CONTEXT.md (#313) =="
for consumer in skills/create-issue/SKILL.md skills/implement-issue/SKILL.md; do
  grep -q "CONTEXT.md" "$consumer" || { echo "FAIL: $consumer does not mention CONTEXT.md"; exit 1; }
  grep -q "_Avoid_" "$consumer" || { echo "FAIL: $consumer does not mention _Avoid_"; exit 1; }
done
echo "ok   create-issue and implement-issue both point at CONTEXT.md and its _Avoid_ lists"

# The map must know where the language lives.
echo "== ARCHITECTURE.md and README.md point at CONTEXT.md (#313) =="
for doc in ARCHITECTURE.md README.md; do
  grep -q "CONTEXT.md" "$doc" || { echo "FAIL: $doc does not mention CONTEXT.md"; exit 1; }
done
echo "ok   ARCHITECTURE.md and README.md both mention CONTEXT.md"

echo "skills golden test: all cases behaved as specified"
