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
# evals/ joins the scratch world for #331: the trigger contract is now
# evals/<skill>-trigger-eval.json, so a root without evals/ answers "trigger eval set missing"
# for every skill. Unlike commands/ it IS mutated — by run_eval_case below, which restores it
# from $PRISTINE the same way run_case restores skills/.
cp -R skills tests commands evals requirements.json "$WORK/root/"
ROOT="$WORK/root"
PRISTINE="$WORK/pristine"
mkdir -p "$PRISTINE"
cp -R "$ROOT/skills" "$PRISTINE/"
cp -R "$ROOT/evals" "$PRISTINE/"

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
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
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
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
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
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^compatibility: >-\n(?:[ \t]+.*\n)+",
           "compatibility: >-\n  Requires python3 and git. Tested against gh CLI at\n"
           "  version: 2.40 or later.\n", t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'
run_case "N3 \"version:\" inside description  " pass '
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
t = re.sub(r"^description: >-\n(?:[ \t]+.*\n)+",
           "description: >-\n  Consolidates open migration follow-ups. Reports the schema\n"
           "  version: 2 payload. Triggers on \"what is still open\", « fais le point ».\n",
           t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
'

echo "== the 750-char soft ceiling WARNs; the guide's 1024 still hard-fails (#323) =="
# The soft ceiling is this suite's first NON-BINARY verdict: it must print a warning and leave the
# exit code alone. run_case keys only on pass/fail, so it cannot tell "warned and accepted" from
# "said nothing and accepted" — which is the whole behaviour under test. Hence a helper that pins
# the exit code AND the output text, with a leading `!` on the pattern asserting its ABSENCE.
#
# run_desc_case <label> <expected exit> <pattern | !pattern> <python mutator>
run_desc_case() {
  local label="$1" want_rc="$2" pattern="$3" mutator="$4"
  rm -rf "$ROOT/skills"
  cp -R "$PRISTINE/skills" "$ROOT/"
  python3 -c "$mutator" "$ROOT"
  local out rc negate=0
  case "$pattern" in '!'*) negate=1; pattern="${pattern#!}" ;; esac
  set +e
  out=$(python3 "$ROOT/tests/skills/check-frontmatter.py" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: [$label] expected exit $want_rc, got $rc"
    echo "      $out"
    fails=$((fails + 1))
    return
  fi
  if grep -qE "$pattern" <<<"$out"; then
    if [ "$negate" -eq 1 ]; then
      echo "FAIL: [$label] exit $rc as expected, but the output matched /$pattern/ and must not"
      echo "      $out"
      fails=$((fails + 1))
      return
    fi
  elif [ "$negate" -eq 0 ]; then
    echo "FAIL: [$label] exit $rc as expected, but the output did not match /$pattern/"
    echo "      $out"
    fails=$((fails + 1))
    return
  fi
  echo "ok   [$label]"
}

# Give review-followups' description exactly $1 NORMALIZED characters (the count the checker uses).
desc_mutator() {
  cat <<PY
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]) / "skills/review-followups/SKILL.md"
t = p.read_text(encoding="utf-8")
body = ("Consolidates the open migration follow-ups and updates them at the source. " * 40)[:$1].strip()
body += "x" * ($1 - len(body))
assert len(body) == $1, len(body)
t = re.sub(r"^description: >-\n(?:[ \t]+.*\n)+", "description: >-\n  " + body + "\n",
           t, count=1, flags=re.M)
p.write_text(t, encoding="utf-8")
PY
}

run_desc_case "W1 850 chars warns, exit unchanged " 0 \
  'WARN review-followups: description is 850 characters' "$(desc_mutator 850)"
run_desc_case "W2 1100 chars still hard-fails    " 1 \
  'review-followups: description is 1100 characters \(guide limit: 1024\)' "$(desc_mutator 1100)"
run_desc_case "W3 750 chars is silent            " 0 \
  '!review-followups: description is' "$(desc_mutator 750)"

# ---------------------------------------------------------------------------------------------
# The trigger contract has one home now: evals/<skill>-trigger-eval.json (#331). check-frontmatter.py
# used to guard tests/skills/<skill>.triggers.md — a bullet list no tool ever read, whose presence CI
# certified while the eval sets it duplicated drifted away from it. The rule moved to the file
# `evals/run_all.py` actually runs, and these cases are the witness that it really refuses, BY NAME,
# each way a set can be malformed. Without them the block could narrow to "the file exists" and every
# run would stay green.
#
# Only evals/ is mutated here — run_case restores skills/, run_eval_case restores evals/ — so the two
# families never disturb each other, and the real tree is never touched either way.
echo "== the trigger contract in evals/*.json must be well-formed (#331) =="

# run_eval_case <label> <expect: pass|fail> <expected marker> <python mutator>
# The mutator receives the scratch root as argv[1] and edits evals/ in place.
run_eval_case() {
  local label="$1" expect="$2" marker="$3" mutator="$4"
  # BOTH trees, every case. evals/ is what these cases mutate, but skills/ carries whatever the
  # last run_case left behind — so an N4 labelled "untouched baseline" would be running against a
  # rewritten description, and inserting one more failing run_case above this block would turn
  # every T case into a coin flip.
  rm -rf "$ROOT/evals" "$ROOT/skills"
  cp -R "$PRISTINE/evals" "$PRISTINE/skills" "$ROOT/"
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
    elif ! grep -q "$marker" <<<"$out"; then
      echo "FAIL: [$label] rejected, but not with '$marker'"
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

run_eval_case "T1 the set is missing entirely    " fail "trigger eval set missing" '
import pathlib, sys
(pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json").unlink()
'

run_eval_case "T2 the set is not valid JSON      " fail "not valid JSON" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
# A trailing comma: the single most common hand-edit typo, and one a bare existence check accepts.
p.write_text("[\n  {\"query\": \"file an issue\", \"should_trigger\": true},\n]\n", encoding="utf-8")
'

run_eval_case "T3 every entry is a positive      " fail "no should_trigger: false entry" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
for e in entries:
    e["should_trigger"] = True
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T3b every entry is a negative     " fail "no should_trigger: true entry" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
for e in entries:
    e["should_trigger"] = False
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T4 an entry has no query          " fail "missing or empty .query." '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
entries[0].pop("query")
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T5 a query is duplicated          " fail "duplicate query" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# A duplicated positive inflates recall for free — the set scores better for saying less.
entries.append(dict(entries[0]))
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T6 an entry carries a stray key   " fail "unexpected key" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# "expect" is the boundary set schema, not this one: a copy-paste the runner would silently ignore.
entries[0]["expect"] = {"create-issue": True}
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T7 the set is an empty list       " fail "non-empty JSON list" '
import pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
p.write_text("[]\n", encoding="utf-8")
'

run_eval_case "T8 a skill drops out of SKILLS     " fail "must list every skill" '
import pathlib, re, sys
# A skill with a valid set that run_all.py never runs: CI reports the contract present, the bench
# silently measures nine of ten. That is the exact failure #331 closed, one edit away from coming back.
# The mutation locates the SKILLS block and drops its first quoted entry whatever the wrapping,
# order or quoting: a literal-substring replace went silently no-op the day the list was re-wrapped
# (#394), and this guard was then never exercised at all. The assert is what makes that loud.
p = pathlib.Path(sys.argv[1]) / "evals/run_all.py"
t = p.read_text(encoding="utf-8")
m = re.search(r"SKILLS\s*=\s*\[(.*?)\]", t, re.S)
assert m, "run_all.py has no SKILLS = [...] block"
block = re.sub(r"\"[^\"]+\",\s*", "", m.group(1), count=1)
assert block != m.group(1), "mutation had no effect (#394)"
p.write_text(t[:m.start(1)] + block + t[m.end(1):], encoding="utf-8")
'

run_eval_case "T9 DEFAULT_KNOWN names a non-skill" fail "must list every skill" '
import pathlib, re, sys
# A stale name in DEFAULT_KNOWN cannot be attributed to any sibling, so a near-miss histogram
# would report a skill that does not exist. Same format-agnostic mutation as T8 (#394).
p = pathlib.Path(sys.argv[1]) / "evals/trigger_eval.py"
t = p.read_text(encoding="utf-8")
m = re.search(r"DEFAULT_KNOWN\s*=\s*\[(.*?)\]", t, re.S)
assert m, "trigger_eval.py has no DEFAULT_KNOWN = [...] block"
block = m.group(1).rstrip().rstrip(",") + ", \"revise-claude-md\""
assert block != m.group(1), "mutation had no effect (#394)"
p.write_text(t[:m.start(1)] + block + t[m.end(1):], encoding="utf-8")
'

run_eval_case "T10 an entry has a non-string note" fail "non-string .note." '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
entries[0]["note"] = 42
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "T11 a duplicate differs only in case" fail "duplicate query" '
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]) / "evals/create-issue-trigger-eval.json"
entries = json.loads(p.read_text(encoding="utf-8"))
# One query asked twice, spelled differently: the bench cannot tell them apart, nor may the guard.
dup = dict(entries[0])
dup["query"] = "  " + dup["query"].upper() + " "
entries.append(dup)
p.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
'

run_eval_case "N4 untouched baseline             " pass "" 'import sys'

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
# resolves to skills/migrate-legacy/_shared/… — a path that does not exist. The reminder reads
# fine and is unreachable, which is the guard emptied of meaning while looking green.
p = pathlib.Path(sys.argv[1]) / "skills/migrate-legacy/references/phase-1-assess.md"
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
# skills/_shared/test-seams.md must exist and create-issue must link it (#310). The Spec
# contract's Testing decisions heading points a reader at this file for the seam doctrine
# (what a seam is, choosing seams before tests, mocking at boundaries only, the three
# anti-patterns) — if the file goes missing or the link erodes, the doctrine and the contract
# silently diverge. Pinned directly against the real tree (no scratch fixture): the defect this
# guards is the committed prose losing its link, not a checker's behavior under mutation.
echo "== create-issue must link skills/_shared/test-seams.md (#310) =="

if [ -f "$KIT_ROOT/skills/_shared/test-seams.md" ]; then
  echo "ok   [S1 skills/_shared/test-seams.md exists     ]"
else
  echo "FAIL: [S1 skills/_shared/test-seams.md exists     ] file is missing"
  fails=$((fails + 1))
fi

if grep -qF '](../_shared/test-seams.md)' "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
  echo "ok   [S2 create-issue/SKILL.md links it          ]"
else
  echo "FAIL: [S2 create-issue/SKILL.md links it          ] missing the literal '](../_shared/test-seams.md)'"
  fails=$((fails + 1))
fi

# issue-template.md lives one directory deeper than SKILL.md (skills/create-issue/references/,
# not skills/create-issue/), so its correct link climbs two levels, not one — this is exactly the
# shape of link a copy-paste from SKILL.md gets wrong.
if grep -qF '](../../_shared/test-seams.md)' "$KIT_ROOT/skills/create-issue/references/issue-template.md" 2>/dev/null; then
  echo "ok   [S3 issue-template.md links it (../../)     ]"
else
  echo "FAIL: [S3 issue-template.md links it (../../)     ] missing the literal '](../../_shared/test-seams.md)'"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "test-seams link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# skills/_shared/grilling.md must exist and create-issue must link it (#312). `--grill` is the one
# sanctioned exception to create-issue's hands-off autonomy contract, and the doctrine that makes it
# safe — one round, the frontier only, facts are the agent's job, unanswered takes the recommended
# answer — lives in the shared file rather than in the skill, because triage-backlog's confirmation
# pass is the second consumer. A `--grill` branch in SKILL.md with no link to that file is a flag
# whose contract nothing states, which is precisely how the two would drift apart. Pinned against
# the real tree for the same reason as the test-seams block above.
echo "== create-issue must link skills/_shared/grilling.md (#312) =="

if [ -f "$KIT_ROOT/skills/_shared/grilling.md" ]; then
  echo "ok   [G1 skills/_shared/grilling.md exists       ]"
else
  echo "FAIL: [G1 skills/_shared/grilling.md exists       ] file is missing"
  fails=$((fails + 1))
fi

if grep -qF '](../_shared/grilling.md)' "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
  echo "ok   [G2 create-issue/SKILL.md links it          ]"
else
  echo "FAIL: [G2 create-issue/SKILL.md links it          ] missing the literal '](../_shared/grilling.md)'"
  fails=$((fails + 1))
fi

# The port is MIT-licensed work by someone else; the credit line is part of the file's contract,
# not a courtesy that may erode in a later edit.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/grilling.md" 2>/dev/null; then
  echo "ok   [G3 grilling.md credits its source          ]"
else
  echo "FAIL: [G3 grilling.md credits its source          ] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "grilling link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The brainstorm, plan and TDD doctrines the lifecycle skills used to invoke from the superpowers
# plugin live under skills/_shared/ now (#324) — one home each, ported from obra/superpowers (MIT)
# and narrowed to this kit's hands-off autonomy contract. A doctrine file nobody links is exactly
# as good as a plugin nobody installed, so each is pinned three ways: it exists, its consumers link
# it (the same literal-link shape as the test-seams and grilling blocks above), and the credit line
# survives — the port is someone else's MIT-licensed work and the attribution is part of the file's
# contract. The header note every filed plan carries is read out of plan-shape.md rather than
# re-spelled here, and the fixture the SP2 case below locates must carry that exact note.
echo "== the ported doctrine references exist, are linked, and credit their source (#324) =="

for ref in brainstorm-and-spec plan-shape tdd-loop; do
  if [ -f "$KIT_ROOT/skills/_shared/$ref.md" ]; then
    echo "ok   [DR1 skills/_shared/$ref.md exists]"
  else
    echo "FAIL: [DR1 skills/_shared/$ref.md exists] file is missing"
    fails=$((fails + 1))
  fi
  if grep -qF 'obra/superpowers' "$KIT_ROOT/skills/_shared/$ref.md" 2>/dev/null; then
    echo "ok   [DR2 _shared/$ref.md credits its source]"
  else
    echo "FAIL: [DR2 _shared/$ref.md credits its source] missing the 'obra/superpowers' attribution"
    fails=$((fails + 1))
  fi
done

for pair in "create-issue:brainstorm-and-spec" "create-issue:plan-shape" "implement-issue:plan-shape" "implement-issue:tdd-loop"; do
  skill="${pair%%:*}"; ref="${pair##*:}"
  if grep -qF "](../_shared/$ref.md)" "$KIT_ROOT/skills/$skill/SKILL.md" 2>/dev/null; then
    echo "ok   [DR3 $skill/SKILL.md links _shared/$ref.md]"
  else
    echo "FAIL: [DR3 $skill/SKILL.md links _shared/$ref.md] missing the literal '](../_shared/$ref.md)'"
    fails=$((fails + 1))
  fi
done

# tdd-loop.md carries two ports: the loop from obra/superpowers (checked above) and the good-test
# and mock-at-boundaries guidance from mattpocock/skills, which earns its own credit line.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/tdd-loop.md" 2>/dev/null; then
  echo "ok   [DR2 _shared/tdd-loop.md credits mattpocock/skills too]"
else
  echo "FAIL: [DR2 _shared/tdd-loop.md credits mattpocock/skills too] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

# The header note has one home. plan-shape.md states it; create-issue cites it rather than carrying
# a second copy that can drift; and the new-note fixture SP2 locates is that exact line.
PLAN_NOTE=$(grep -m1 '^> \*\*For agentic workers:\*\*' "$KIT_ROOT/skills/_shared/plan-shape.md" 2>/dev/null || true)
if [ -z "$PLAN_NOTE" ]; then
  echo "FAIL: [DR4 plan-shape.md states the header note] no '> **For agentic workers:**' line"
  fails=$((fails + 1))
elif printf '%s' "$PLAN_NOTE" | grep -q 'superpowers\|SUB-SKILL'; then
  echo "FAIL: [DR4 plan-shape.md states the header note] the note still prescribes the plugin: $PLAN_NOTE"
  fails=$((fails + 1))
elif ! printf '%s' "$PLAN_NOTE" | grep -qF 'implement-issue'; then
  echo "FAIL: [DR4 plan-shape.md states the header note] the note does not name implement-issue as the executor: $PLAN_NOTE"
  fails=$((fails + 1))
elif ! grep -qFx -- "$PLAN_NOTE" "$KIT_ROOT/tests/skills/fixtures/plan-new-header-note.md"; then
  echo "FAIL: [DR4 plan-shape.md states the header note] fixtures/plan-new-header-note.md does not carry plan-shape.md's exact note"
  fails=$((fails + 1))
else
  echo "ok   [DR4 plan-shape.md states the header note, and the new-note fixture carries it]"
fi
if grep -q 'REQUIRED SUB-SKILL' "$KIT_ROOT/skills/create-issue/SKILL.md" "$KIT_ROOT/skills/create-issue/references/issue-template.md" 2>/dev/null; then
  echo "FAIL: [DR5 create-issue no longer writes the old header note] 'REQUIRED SUB-SKILL' still appears in create-issue"
  fails=$((fails + 1))
else
  echo "ok   [DR5 create-issue no longer writes the old header note]"
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "doctrine references golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# skills/_shared/prior-rejections.md must exist, and all THREE consumers must link it (#319). A
# prior rejection is an ADR with `status: rejected`; the lookup that consults it runs at every inlet
# (`create-issue` Step 3, `merge-pr` 6c) and the pass that judges the queue (`triage-backlog` Step
# 4), while the authoring half runs in `triage-backlog` Step 7 alone. That asymmetry — three readers,
# one writer — is exactly the kind of rule that gets restated slightly differently in each SKILL.md
# and then drifts, which is why it has one home and why a SKILL.md that stops pointing at that home
# is a failure rather than a style question.
#
# `filing-bar.md` is checked too, and for a stronger reason than the others: its clause 4 is a VETO
# over gates 1-3, and a veto whose lookup recipe is not linked is a rule an inlet cannot actually
# apply. Pinned against the real tree — the defect IS the committed prose.
echo "== the prior-rejection recipe has one home, and its four consumers link it (#319) =="

if [ -f "$KIT_ROOT/skills/_shared/prior-rejections.md" ]; then
  echo "ok   [PR1 prior-rejections.md exists          ]"
else
  echo "FAIL: [PR1 prior-rejections.md exists          ] file is missing"
  fails=$((fails + 1))
fi

for consumer in create-issue merge-pr triage-backlog; do
  if grep -qF '](../_shared/prior-rejections.md)' \
      "$KIT_ROOT/skills/$consumer/SKILL.md" 2>/dev/null; then
    printf 'ok   [PR2 %-14s SKILL.md links it    ]\n' "$consumer"
  else
    printf 'FAIL: [PR2 %-14s SKILL.md links it    ] missing the literal\n' "$consumer"
    echo "      '](../_shared/prior-rejections.md)'"
    fails=$((fails + 1))
  fi
done

# Same directory, so the link is `](./prior-rejections.md)` rather than `](../_shared/…)`.
if grep -qF '](./prior-rejections.md)' "$KIT_ROOT/skills/_shared/filing-bar.md" 2>/dev/null; then
  echo "ok   [PR3 filing-bar.md links the recipe      ]"
else
  echo "FAIL: [PR3 filing-bar.md links the recipe      ] clause 4 is a veto over gates 1-3; without"
  echo "      the literal '](./prior-rejections.md)' it names no way to apply it"
  fails=$((fails + 1))
fi

# The port is MIT-licensed work by someone else; the credit is part of the file's contract, not a
# courtesy a later edit may drop. Same rule as G3 above.
if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/_shared/prior-rejections.md" 2>/dev/null; then
  echo "ok   [PR4 prior-rejections.md credits source  ]"
else
  echo "FAIL: [PR4 prior-rejections.md credits source  ] missing the 'mattpocock/skills' attribution"
  fails=$((fails + 1))
fi

# The degraded path has to be NAMED, not merely implied. A recipe that describes only the semantic
# lookup reads as "no lookup happened" on every machine without the server, which is the one outcome
# the fallback exists to prevent — and the helper it names is the only shell surface under test.
if grep -qF 'rejected-adrs.sh' "$KIT_ROOT/skills/_shared/prior-rejections.md" 2>/dev/null; then
  echo "ok   [PR5 the recipe names its fallback       ]"
else
  echo "FAIL: [PR5 the recipe names its fallback       ] missing 'rejected-adrs.sh' — without the"
  echo "      fallback named, a reader with no AdrMcp has nothing to run"
  fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "prior-rejection link golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The decompose branch (#315) hangs off two references — the parent's tracking-body shape and
# the slicing rules — and create-issue must link both. The parent-body invariant they carry (no
# `Implementation plan`, no `### Task`, no `- [ ]`) is what keeps survey.sh's `haveplan` false so
# a tracking parent is never dispatched; a SKILL.md that stops linking the file stating it is a
# branch whose contract nothing states. Pinned against the real tree, same as the blocks above.
echo "== create-issue must link its decomposition references (#315) =="

for ref in tracking-issue decomposition; do
  if [ -f "$KIT_ROOT/skills/create-issue/references/$ref.md" ]; then
    echo "ok   [D1 references/$ref.md exists]"
  else
    echo "FAIL: [D1 references/$ref.md exists] file is missing"
    fails=$((fails + 1))
  fi
  if grep -qF "](references/$ref.md)" "$KIT_ROOT/skills/create-issue/SKILL.md" 2>/dev/null; then
    echo "ok   [D2 create-issue/SKILL.md links references/$ref.md]"
  else
    echo "FAIL: [D2 create-issue/SKILL.md links references/$ref.md] missing the literal '](references/$ref.md)'"
    fails=$((fails + 1))
  fi
  # The port is MIT-licensed work by someone else; the credit line is part of each file's contract.
  if grep -qF 'mattpocock/skills' "$KIT_ROOT/skills/create-issue/references/$ref.md" 2>/dev/null; then
    echo "ok   [D3 references/$ref.md credits its source]"
  else
    echo "FAIL: [D3 references/$ref.md credits its source] missing the 'mattpocock/skills' attribution"
    fails=$((fails + 1))
  fi
done

# triage-backlog's rescope emits the same parent + children shape, so it links the parent shape too.
if grep -qF '](../create-issue/references/tracking-issue.md)' "$KIT_ROOT/skills/triage-backlog/SKILL.md" 2>/dev/null; then
  echo "ok   [D4 triage-backlog/SKILL.md links tracking-issue.md]"
else
  echo "FAIL: [D4 triage-backlog/SKILL.md links tracking-issue.md] missing the literal '](../create-issue/references/tracking-issue.md)'"
  fails=$((fails + 1))
fi

# The shape the reference documents is the one survey.sh reads: its example parent body must
# itself carry none of the three plan tokens, or the reference teaches the wrong invariant.
if [ -f "$KIT_ROOT/skills/create-issue/references/tracking-issue.md" ]; then
  if sed -n '/^```markdown$/,/^```$/p' "$KIT_ROOT/skills/create-issue/references/tracking-issue.md" \
       | grep -qE 'Implementation plan|### Task|- \[ \]'; then
    echo "FAIL: [D5 tracking-issue.md's example body carries a plan token] a fenced example contains 'Implementation plan', '### Task' or '- [ ]'"
    fails=$((fails + 1))
  else
    echo "ok   [D5 tracking-issue.md's example bodies carry no plan token]"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "decomposition references golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The main-worktree derivation has one home now (#125): scripts/main-worktree.sh. Two broken
# spellings kept getting re-introduced before that — a caller resolving `-C` from
# `git rev-parse --show-toplevel` right next to a worktrees-ignored.sh call (fails OPEN from a
# linked worktree, tests/worktrees-ignored/test.sh case 22) and an `awk '{p=$2}'` listing that
# truncates a checkout under a path containing a space. This is the anti-recurrence guard: it
# scans the real skills/ tree, not a scratch copy, because the defect IS the committed prose and
# scripts, not something a fixture could stand in for.
#
# Proximity, not "the file mentions both": skills/profile-repo/scripts/repo-profile.sh
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
# The `claude -p` worker substrate is gone (#314, the v2.0 breaking change): auto-dev dispatches
# every worker as an in-process background sub-agent through the Agent tool, and a sub-agent has
# no `--strict-mcp-config` flag and no process to die. Any file that still names either is stale
# doctrine a supervisor would follow — it scans the real tree, not a scratch copy, because the
# defect IS the committed prose. `evals/` legitimately keeps `claude -p` (it drives the eval
# harness, not a worker) and is deliberately outside the scope below.
echo "== no auto-dev file names the claude -p worker substrate (#314) =="
SUBSTRATE_HITS=$(grep -rn 'claude -p\|--strict-mcp-config' \
  "$KIT_ROOT/skills/auto-dev" \
  "$KIT_ROOT/commands/auto-dev-worker.md" \
  "$KIT_ROOT/commands/auto-dev-merge.md" \
  "$KIT_ROOT/skills/_shared/untrusted-input-boundary.md" || true)
if [ -n "$SUBSTRATE_HITS" ]; then
  echo "FAIL: the claude -p / --strict-mcp-config worker substrate is named again (#314):"
  echo "$SUBSTRATE_HITS" | sed 's/^/  /'
  exit 1
fi
echo "ok   no auto-dev file names claude -p or --strict-mcp-config"

# ---------------------------------------------------------------------------------------------
# The lifecycle skills no longer depend on the third-party superpowers plugin (#324): the
# brainstorm, plan and TDD doctrines they used to invoke live under skills/_shared/, and an
# `Invoke superpowers:X` line on a machine without the plugin degrades silently — the Skill tool
# has no such name, and the agent improvises whatever shape it likes. So the colon-invocation form
# is refused anywhere a session actually reads: skills/ and commands/. The bare word is still
# allowed — debug-issue's compatibility credit ("ported from the superpowers skill") and
# docs/superpowers/ (historical plans, a directory name) are attribution and history, not
# invocations. Scans the real tree, not a scratch copy: the defect IS the committed prose.
echo "== no shipped skill or command invokes a superpowers: skill (#324) =="
SUPERPOWERS_HITS=$(grep -rn 'superpowers:' "$KIT_ROOT/skills" "$KIT_ROOT/commands" || true)
if [ -n "$SUPERPOWERS_HITS" ]; then
  echo "FAIL: [SP1 no superpowers: invocation in skills/ or commands/] the plugin is named again (#324):"
  echo "$SUPERPOWERS_HITS" | sed 's/^/  /'
  fails=$((fails + 1))
else
  echo "ok   [SP1 no superpowers: invocation in skills/ or commands/]"
fi

# The header note every filed plan carries changed with #324, and every issue filed before it still
# carries the old one. implement-issue keeps executing both because its Step 2 locator anchors on
# the `🛠️ Implementation plan` heading, never on the note — this case pins that: the anchor is
# read out of the recipe itself (a re-spelling here would pass while the recipe drifted), it must
# not name the plugin, and it must hit a fixture of each note with the same task count.
echo "== implement-issue locates a plan under either header note (#324) =="
MECH="$KIT_ROOT/skills/implement-issue/references/github-mechanics.md"
RECIPE_LINE_RE="grep -q '[^']*' /tmp/plan-\$ISSUE.md"   # tmp-lint:allow — the recipe's own text being matched, not a path this suite writes
PLAN_ANCHOR=$(grep -o "$RECIPE_LINE_RE" "$MECH" | head -1 | sed "s/^grep -q '\(.*\)' .*$/\1/")
if [ -z "$PLAN_ANCHOR" ]; then
  echo "FAIL: [SP2 the §2 locator anchor is readable          ] no \"grep -q '…' <plan file>\" line in $MECH"
  fails=$((fails + 1))
elif printf '%s' "$PLAN_ANCHOR" | grep -qi 'superpowers\|SUB-SKILL\|agentic workers'; then
  echo "FAIL: [SP2 the §2 locator anchor is readable          ] anchors on the header note ('$PLAN_ANCHOR'), not the heading"
  fails=$((fails + 1))
else
  echo "ok   [SP2 the §2 locator anchor is readable          ] '$PLAN_ANCHOR'"
  for note in old new; do
    FIXTURE="$KIT_ROOT/tests/skills/fixtures/plan-$note-header-note.md"
    if ! grep -qF -- "$PLAN_ANCHOR" "$FIXTURE"; then
      echo "FAIL: [SP2 $note header note is located             ] anchor '$PLAN_ANCHOR' misses $FIXTURE"
      fails=$((fails + 1))
    elif [ "$(grep -c '^### Task ' "$FIXTURE")" -ne 2 ]; then
      echo "FAIL: [SP2 $note header note is located             ] expected 2 '### Task' blocks in $FIXTURE, got $(grep -c '^### Task ' "$FIXTURE")"
      fails=$((fails + 1))
    else
      echo "ok   [SP2 $note header note is located             ] anchor hit, 2 '### Task' blocks in the fixture"
    fi
  done
fi

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "superpowers-independence golden test: all cases behaved as specified"

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

# ---------------------------------------------------------------------------------------------
# preconditions.md refuses a non-GitHub tracker in one sentence (#311). Fixture-free: this is a
# grep against the committed reference itself, not a probe run against a scratch repo — the
# probe/profile side of the Tracker line is pinned by tests/repo-profile/test.sh.
echo "== preconditions refuse a non-GitHub tracker (#311) =="
PRECONDITIONS="$KIT_ROOT/skills/_shared/preconditions.md"
[ -f "$PRECONDITIONS" ] || { echo "FAIL: $PRECONDITIONS missing"; exit 1; }
grep -q 'Tracker' "$PRECONDITIONS" \
  || { echo "FAIL: $PRECONDITIONS does not mention the profile's Tracker line"; exit 1; }
grep -q 'not a supported tracker' "$PRECONDITIONS" \
  || { echo "FAIL: $PRECONDITIONS does not refuse a non-GitHub tracker in these words"; exit 1; }
echo "ok   preconditions names Tracker and refuses a non-GitHub tracker"

# ---------------------------------------------------------------------------------------------
# The roseline-gate essay moved to docs/roseline-gate.md (#325). Fixture-free: the defect this
# guards is the committed essay drifting away from its own four properties, or the README's link
# to it eroding, not something a scratch fixture could stand in for.
echo "== docs/roseline-gate.md carries the roseline-gate essay, linked from README (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "docs" / "roseline-gate.md"
if not path.is_file():
    print("FAIL: docs/roseline-gate.md missing")
    sys.exit(1)

text = path.read_text(encoding="utf-8")
for phrase in (
    "Inert outside C# projects",
    "A one-shot escape",
    "Fails open, always",
    "never enforces a tool that cannot be there",
):
    if phrase not in text:
        print("FAIL: docs/roseline-gate.md is missing the phrase %r" % phrase)
        sys.exit(1)

readme = (root / "README.md").read_text(encoding="utf-8")
if "docs/roseline-gate.md" not in readme:
    print("FAIL: README.md does not link docs/roseline-gate.md")
    sys.exit(1)

print("ok   docs/roseline-gate.md carries the four properties, and README links it")
PY

# ---------------------------------------------------------------------------------------------
# README leads with the failure modes and a "Which command?" table, and links every skill and
# command (#325). Fixture-free, same reason as the #313 CONTEXT.md case above: the defect is the
# committed README drifting out of shape, not something a scratch fixture models better.
echo "== README leads with failure modes, routes by situation, links every skill/command (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
readme = (root / "README.md").read_text(encoding="utf-8")

for heading in ("## Why this kit exists", "## Which command?"):
    if heading not in readme:
        print("FAIL: README.md is missing the heading %r" % heading)
        sys.exit(1)

targets = set(re.findall(r"\]\(([^)]+)\)", readme))

missing = []
for skill_dir in sorted((root / "skills").iterdir()):
    if not skill_dir.is_dir() or skill_dir.name == "_shared":
        continue
    rel = "skills/%s/SKILL.md" % skill_dir.name
    if not (root / rel).is_file():
        continue
    if rel not in targets:
        missing.append(rel)

for cmd in sorted((root / "commands").glob("*.md")):
    rel = "commands/%s" % cmd.name
    if rel not in targets:
        missing.append(rel)

if missing:
    print("FAIL: README.md does not link: %s" % ", ".join(missing))
    sys.exit(1)

print("ok   README.md links every skills/*/SKILL.md and commands/*.md")
PY

# ------------------------------------------------------------------------------------------------
# The methodology guide names every skill and every command (#398). docs/methodology.md is the one
# document that reads the kit end to end; a skill added without a place in it is the README-links
# failure one level up — the guard walks the same directories that case does and greps the guide.
# Driven to red on a scratch copy of the tree with an extra skill folder, so the guard cannot go
# silent by matching nothing.
echo "== docs/methodology.md names every skill and command (#398) =="
# ONE check, written to a file and run twice — on the real tree (must pass) and on a scratch tree
# with an unnamed skills/zz-fake/ (must fail, and must NAME zz-fake). A second inline copy of the
# check would prove the copy, not the case; the red half is the guard that proves the guard.
_gscratch=$(kit_scratch)
cat > "$_gscratch/guide-check.py" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
guide = root / "docs/methodology.md"
if not guide.exists():
    print("FAIL: docs/methodology.md is missing"); sys.exit(1)
text = guide.read_text(encoding="utf-8")
missing = []
for d in sorted(p for p in (root / "skills").iterdir() if p.is_dir() and p.name != "_shared"):
    if d.name not in text:
        missing.append("skills/" + d.name)
for f in sorted((root / "commands").glob("*.md")):
    if f.stem not in text:
        missing.append("commands/" + f.name)
if missing:
    print("FAIL: docs/methodology.md never names: " + ", ".join(missing)); sys.exit(1)
print("ok   docs/methodology.md names every skill folder and every command")
PY
python3 "$_gscratch/guide-check.py" "$KIT_ROOT" || exit 1
mkdir -p "$_gscratch/tree/skills/zz-fake" "$_gscratch/tree/commands" "$_gscratch/tree/docs"
cp "$KIT_ROOT/docs/methodology.md" "$_gscratch/tree/docs/"
cp -R "$KIT_ROOT/skills/debug-issue" "$_gscratch/tree/skills/"
: > "$_gscratch/tree/skills/zz-fake/SKILL.md"
if python3 "$_gscratch/guide-check.py" "$_gscratch/tree" > "$_gscratch/guide-red.out" 2>&1; then
  echo "FAIL: the guide-coverage check accepted a tree with skills/zz-fake/ unnamed"; exit 1
fi
grep -q 'skills/zz-fake' "$_gscratch/guide-red.out" \
  || { echo "FAIL: the guide-coverage check refused the scratch tree without naming skills/zz-fake"; cat "$_gscratch/guide-red.out"; exit 1; }
echo "ok   a skill folder the guide does not name is refused, by name"

# ---------------------------------------------------------------------------------------------
# A pointer-only CLAUDE.md for agents working on the kit (#325). Exactly one of the two documented
# locations, a line budget so it stays pointers rather than sediment, and every relative link
# actually resolves — a link that used to work but now 404s is worse than no pointer at all.
echo "== exactly one pointer-only CLAUDE.md exists, <= 60 lines, links resolve (#325) =="
python3 - "$KIT_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
candidates = [root / "CLAUDE.md", root / ".claude" / "CLAUDE.md"]
present = [p for p in candidates if p.is_file()]
if len(present) != 1:
    print("FAIL: expected exactly one of CLAUDE.md / .claude/CLAUDE.md, found %d" % len(present))
    sys.exit(1)

path = present[0]
lines = path.read_text(encoding="utf-8").splitlines()
if len(lines) > 60:
    print("FAIL: %s has %d lines, over the 60-line budget" % (path, len(lines)))
    sys.exit(1)

text = "\n".join(lines)
for m in re.finditer(r"\]\(([^)]+)\)", text):
    target = m.group(1)
    if target.startswith("http://") or target.startswith("https://") or target.startswith("#"):
        continue
    target_path = target.split("#", 1)[0]
    resolved = (path.parent / target_path).resolve()
    if not resolved.exists():
        print("FAIL: %s links %r, which does not resolve (tried %s)" % (path, target, resolved))
        sys.exit(1)

print("ok   %s exists, is <= 60 lines, and every relative link resolves" % path.relative_to(root))
PY
# create-issue consults the accepted ADRs before it brainstorms (#316). The touchpoint is prose and
# cannot go red on its own, so this pins the three load-bearing spellings: the server tool it calls,
# the verdict it must write when an idea contradicts a decision, and the file fallback for a host
# with no AdrMcp.
echo "== create-issue checks the idea against accepted ADRs (#316) =="
CREATE_ISSUE="$KIT_ROOT/skills/create-issue/SKILL.md"
[ -f "$CREATE_ISSUE" ] || { echo "FAIL: $CREATE_ISSUE missing"; exit 1; }
for needle in 'search_adrs' 'contradicts ADR-' 'docs/adr'; do
  grep -q "$needle" "$CREATE_ISSUE" \
    || { echo "FAIL: $CREATE_ISSUE does not mention '$needle'"; exit 1; }
done
echo "ok   create-issue names search_adrs, the contradiction verdict and the docs/adr fallback"

# ---------------------------------------------------------------------------------------------
# A diff that touches an accepted ADR's `code_refs` proposes an ADR update rather than making one
# (#316). Both consumers get the same paragraph, so both are pinned — and each must name
# `suggest_adr_from_change` AND the `## Follow-ups` heading the draft lands under, because a draft
# named without a destination is the failure mode this touchpoint exists to avoid.
echo "== implement-issue and merge-pr propose an ADR update, never write one (#316) =="
for f in "skills/implement-issue/SKILL.md" "skills/merge-pr/SKILL.md"; do
  path="$KIT_ROOT/$f"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  for needle in 'suggest_adr_from_change' '## Follow-ups' 'code_refs' 'docs/adr'; do
    grep -q -- "$needle" "$path" \
      || { echo "FAIL: $path does not mention '$needle'"; exit 1; }
  done
done
echo "ok   both consumers name suggest_adr_from_change, ## Follow-ups and the docs/adr fallback"

# ---------------------------------------------------------------------------------------------
# AdrMcp is documented as shipped, next to the RoselineMCP paragraph it mirrors, and the ADR index
# is reachable from both entry documents (#316). A dependency the kit ships without saying so is
# the failure this pins — the README already carries that promise for roseline.
echo "== README and ARCHITECTURE document AdrMcp and the ADR root (#316) =="
for f in "README.md" "ARCHITECTURE.md"; do
  path="$KIT_ROOT/$f"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  for needle in 'AdrMcp' 'docs/adr'; do
    grep -q -- "$needle" "$path" \
      || { echo "FAIL: $path does not mention '$needle'"; exit 1; }
  done
done
echo "ok   README and ARCHITECTURE both name AdrMcp and docs/adr"

# ---------------------------------------------------------------------------------------------
# merge-pr reads the base-branch CI run its OWN merge triggered, and always says what it found
# (#355). The skill used to end its contract at "the PR is MERGED": two PRs each green against
# their own base combined into a red `main` (f17c85c, 2026-08-30) and nobody read the push run,
# because both merges had already reported success and torn down.
#
# Three things are pinned, and the third is the one that keeps the step honest. The step itself,
# so it cannot be quietly dropped; the helper, so the skill cannot grow a second, hand-rolled CI
# reader beside it; and ALL THREE report outcomes, because an `unverified` that never reaches the
# report is indistinguishable from the silence this whole change removes — a merge whose base run
# was cancelled by the next merge in the train is the COMMON case, not an edge one.
echo "== merge-pr reports the base CI verdict its own merge produced (#355) =="
skill="$KIT_ROOT/skills/merge-pr/SKILL.md"
[ -f "$skill" ] || { echo "FAIL: $skill missing"; exit 1; }
for needle in 'Step 5b' 'base-run-verdict.sh' 'base green at' 'base RED at' 'base unverified at'; do
  grep -q -F -- "$needle" "$skill" \
    || { echo "FAIL: $skill does not name '$needle' — Step 5b is not wired into the skill"; exit 1; }
done
# Never revert, and never stop. Both are autonomy-contract promises the step makes in prose only,
# so prose is where they have to be pinned: an autonomous fleet that gained a post-merge stop, or
# a skill that reverted somebody else's merge on an inherited red, are the two ways this step
# turns into a worse failure than the one it fixes.
grep -q -i -- 'never revert' "$skill" \
  || { echo "FAIL: $skill no longer says Step 5b never reverts"; exit 1; }
# The by-sha resolution recipe has one home, beside the §3 check-runs recipe it reuses.
mech="$KIT_ROOT/skills/merge-pr/references/merge-mechanics.md"
[ -f "$mech" ] || { echo "FAIL: $mech missing"; exit 1; }
grep -q -F -- 'base-run-verdict.sh' "$mech" \
  || { echo "FAIL: $mech carries no base-run resolution recipe"; exit 1; }
echo "ok   merge-pr names Step 5b, the helper, and all three base outcomes in its report"
# Three ways Step 5b could be written and still pass every check above, each found by review and
# each producing a WRONG report rather than a missing one — so each gets its own witness:
#   * `guarded-pr-merge.sh` prints the literal `<unknown-sha>` when its readback finds no
#     mergeCommit.oid. That is not a hex sha, the helper refuses it (exit 64 — its one non-answer),
#     and the snippet's three branches all fall through to nothing.
#   * a merge train inherits one red across several DIFFERENT squash shas, so a sha-keyed
#     de-duplication never matches and N workers file N bugs for one root cause.
#   * the resume path (`state == MERGED` on entry) has no $MERGE_OUT to read a sha from, and
#     `auto-dev` now reads a BASE: field off exactly the report line that path produces.
for needle in 'mergeCommit' 'the same job(s)' 'resumed after the merge'; do
  grep -q -F -- "$needle" "$skill" \
    || { echo "FAIL: $skill Step 5b lost its guard for '$needle'"; exit 1; }
done
echo "ok   Step 5b guards the unknown-sha sentinel, folds on the breakage, and survives a resume"


# The fleet inherits Step 5b through its workers, so the answer has to survive the report boundary:
# a phase-2 worker that folds "the base went red" into free-text DETAIL is indistinguishable, on the
# orchestrator's state board, from a clean merge. Both halves are pinned — the field on the report
# line the worker emits, and the place the board puts it — because either one alone re-hides it.
echo "== a red base after a worker's merge is fleet-visible (#355) =="
for f in "skills/auto-dev/SKILL.md" "commands/auto-dev-merge.md"; do
  path="$KIT_ROOT/$f"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  grep -q -F -- 'BASE:' "$path" \
    || { echo "FAIL: $path's phase-2 report line carries no BASE: field"; exit 1; }
done
grep -q -F -- 'MERGED (<commit>) — base' "$KIT_ROOT/skills/auto-dev/SKILL.md" \
  || { echo "FAIL: the auto-dev state board's Completed row does not carry the base verdict"; exit 1; }
echo "ok   auto-dev carries the base verdict on the report line and the state board"


echo "skills golden test: all cases behaved as specified"

# ---------------------------------------------------------------------------------------------
# The trigger contract has ONE home, and the records say so (#331). The ten
# tests/skills/<name>.triggers.md lists were a CACHE of the eval sets — a second copy of a contract
# nothing ran, which CI certified while the sets it duplicated drifted away from it. Deleting them
# is only half the fix: as long as a live document still points a reader at that path, the cache is
# rebuilt the first time someone follows the pointer. So this pins the pointer, not just the files.
#
# Pinned against the real tree (no scratch fixture): the defect IS the committed prose.
echo "== the trigger contract has one home, and the records name it (#331) =="

# Not `compgen -G`: it answers 1 for "no matches" AND for "not a builtin / progcomp disabled",
# so a guard whose whole job is anti-recurrence would print ok when it never ran at all.
r1_found=0
for f in "$KIT_ROOT"/tests/skills/*.triggers.md; do
  [ -e "$f" ] && r1_found=1
done
if [ "$r1_found" -ne 0 ]; then
  echo "FAIL: [R1 no tests/skills/*.triggers.md         ] a retired trigger list is back — the"
  echo "      contract lives in evals/<skill>-trigger-eval.json, guarded by check-frontmatter.py"
  fails=$((fails + 1))
else
  echo "ok   [R1 no tests/skills/*.triggers.md         ]"
fi

# Only these may still say "triggers.md", and each for a reason that is not a pointer:
#   CHANGELOG.md, reviews/  — dated, immutable records of what the kit did on a given day;
#                             rewriting them would falsify history (CHANGELOG.md is release-please's).
#   docs/backlog.md         — the entry rewritten as a CLOSED item, which has to name what closed.
#   tests/skills/*.py|sh    — this suite and the checker, explaining the rule they replaced.
# Anything else naming the path is a live pointer at a home that no longer exists.
R2_ALLOWED="CHANGELOG.md docs/backlog.md tests/skills/check-frontmatter.py tests/skills/test.sh"
r2_hits=$(git -C "$KIT_ROOT" grep -l -F "triggers.md" -- . 2>/dev/null || true)
r2_unexpected=""
# THIS file always matches (its own R1 glob is spelled below), so an empty or sentinel-less result
# means `git grep` failed rather than that the tree is clean — the one way this guard could pass
# while never having looked.
if ! grep -qx "tests/skills/test.sh" <<<"$r2_hits"; then
  echo "FAIL: [R2 no live pointer at the retired path  ] the git-grep sweep did not even find this"
  echo "      file, which always matches — the search failed; the verdict below would be vacuous"
  fails=$((fails + 1))
else
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in reviews/*) continue ;; esac
  case " $R2_ALLOWED " in *" $f "*) continue ;; esac
  r2_unexpected="$r2_unexpected $f"
done <<< "$r2_hits"
if [ -n "$r2_unexpected" ]; then
  echo "FAIL: [R2 no live pointer at the retired path  ]$r2_unexpected"
  echo "      still names tests/skills/<name>.triggers.md — point it at evals/<skill>-trigger-eval.json"
  fails=$((fails + 1))
else
  echo "ok   [R2 no live pointer at the retired path  ]"
fi
fi

# C: pin the ROW, not the filename. `grep -qF trigger-eval.json` over the whole file passes even if
#    the "Where each concern lives" row is deleted and the path appears in unrelated prose — which
#    is the very thing R3's own failure message claims to be checking.
if grep -qE '^\| Triggering contracts \|[^|]*evals/<name>-trigger-eval\.json' "$KIT_ROOT/ARCHITECTURE.md" 2>/dev/null; then
  echo "ok   [R3 ARCHITECTURE.md names the new home   ]"
else
  echo "FAIL: [R3 ARCHITECTURE.md names the new home   ] its \"Where each concern lives\" row must"
  echo "      point Triggering contracts at evals/<name>-trigger-eval.json"
  fails=$((fails + 1))
fi

# ---------------------------------------------------------------------------------------------
# The two auto-dev command files are DISPATCHED by name, so each carries ONE human-facing line and
# leaves the phase contract to its body (#323) — they were the longest descriptions in commands/,
# each re-stating what its own body already says.
#
# What they must NOT carry is `disable-model-invocation` (#323 review). #323's spec proposed it on
# the reasoning that "the supervisor never asks the model to FIND /auto-dev-worker" — true of
# discovery, false of invocation, and the key gates invocation. Since #314 a worker is an in-process
# SUB-AGENT: `skills/auto-dev/SKILL.md` dispatches `Agent(prompt: "Invoke \`auto-dev-worker\` with
# args <N>")`, and that sub-agent is a model whose first act is to invoke the command. Disabling
# model invocation would leave every phase-1 and phase-2 worker in the fleet unable to reach its own
# contract. Both halves are pinned so neither can drift back.
#
# Pinned against the real tree (no scratch fixture): the defect IS the committed frontmatter.
echo "== the dispatched auto-dev commands carry one line, and stay model-invocable (#323) =="
D_CHECK=$(cat <<'PY'
import re, sys, yaml
t = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---\n", t, re.S)
fm = yaml.safe_load(m.group(1)) if m else None
if not isinstance(fm, dict):
    sys.exit("frontmatter absent or not a YAML mapping")
if "disable-model-invocation" in fm:
    sys.exit("disable-model-invocation is set — since #314 the auto-dev worker is an in-process "
             "sub-agent that INVOKES this command through the Skill tool, so disabling model "
             "invocation breaks every worker in the fleet (#323 review)")
desc = " ".join(str(fm.get("description") or "").split())
if not desc:
    sys.exit("description missing — the slash-command list still shows it to a human")
if len(desc) > 200:
    sys.exit("description is %d characters — a dispatched command keeps ONE human-facing "
             "line (<= 200); the phase contract belongs in the body" % len(desc))
if not str(fm.get("argument-hint") or "").strip():
    sys.exit("argument-hint missing — it is how a human learns the argument")
PY
)
for cmd in auto-dev-worker auto-dev-merge; do
  set +e
  d_out=$(python3 -c "$D_CHECK" "$KIT_ROOT/commands/$cmd.md" 2>&1)
  d_rc=$?
  set -e
  if [ "$d_rc" -eq 0 ]; then
    echo "ok   [D1 commands/$cmd.md one line, invocable]"
  else
    echo "FAIL: [D1 commands/$cmd.md one line, invocable] $d_out"
    fails=$((fails + 1))
  fi
done

if [ "$fails" -ne 0 ]; then
  echo "$fails case(s) failed"
  exit 1
fi
echo "one-trigger-home golden test: all cases behaved as specified"
