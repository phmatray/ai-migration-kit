#!/usr/bin/env bash
# Golden test for skills/implement-issue/scripts/plan-freshness.sh and the SKILL.md prose that
# consumes it (#322).
#
# Why this exists. `implement-issue` Step 2 parses a plan that was written when the issue was
# FILED and executes it however long afterwards — #233 and #245 both trace to a `**Files:**` line
# naming a path that `main` no longer had. The failure shape is the one this repo keeps closing:
# nothing reports a problem. A subagent opens the file, finds it absent, improvises a nearby one,
# the task goes green, and Step 10 never says the plan was stale. `plan-freshness.sh` turns that
# silence into an exit code, and this suite drives both of its verdicts plus its refusal.
#
# The seam is the script's own CLI: argv in, stdout lines + exit code out, run against a scratch
# git repository built here (skills/_shared/test-seams.md — highest boundary a test can reach, and
# the one CI and Step 2 both actually depend on). Nothing is sourced; no internal is asserted on.
#
# Ported alongside the mechanisms in skills/implement-issue/references/spec-review.md from
# mattpocock/skills (MIT) — `engineering/code-review` and `in-progress/implement-spec`.
set -euo pipefail
cd "$(dirname "$0")/../.."

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT_ROOT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT_ROOT"
kit_guard kit_guard_samples_unchanged

SCRIPT="$KIT_ROOT/skills/implement-issue/scripts/plan-freshness.sh"
SKILL="$KIT_ROOT/skills/implement-issue/SKILL.md"
MECHANICS="$KIT_ROOT/skills/implement-issue/references/github-mechanics.md"
SPEC_REVIEW="$KIT_ROOT/skills/implement-issue/references/spec-review.md"
WORK=$(kit_scratch)

FAILED=0
note_fail() { echo "FAIL: $1"; FAILED=1; }
note_ok()   { echo "ok   [$1]"; }

[ -x "$SCRIPT" ] || {
  echo "FAIL: $SCRIPT is missing or not executable — there is nothing to drive."
  echo "      Step 2 of implement-issue calls it by that path; a suite that skipped here would"
  echo "      report green about a script CI would fail on."
  exit 1; }

# ------------------------------------------------------------------ 1. the scratch repository
#
# A real repository, not a fixture directory: the script's whole job is `git cat-file -e <ref>:<p>`,
# so a stub of git would move the seam from "does this resolve against a ref" to "does this call
# the function I named git" — the mocking anti-pattern in _shared/test-seams.md.
REPO="$WORK/repo"
mkdir -p "$REPO/dir with space"
git -C "$REPO" init -q
git -C "$REPO" config user.email "suite@example.invalid"
git -C "$REPO" config user.name "plan-freshness suite"
printf 'x\n' > "$REPO/a.sh"
printf 'y\n' > "$REPO/dir with space/b.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "init"

# `origin/main` without a remote: the script's default base is a ref name, and a remote-tracking
# ref is just a ref. This keeps the default path under test without a network or a second clone.
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

# A second ref where a.sh does NOT exist, so `--base` is proved to be READ rather than accepted and
# ignored — a flag that is parsed and discarded passes every test that only ever spells the default.
git -C "$REPO" checkout -q -b without-a
git -C "$REPO" rm -q "a.sh"
git -C "$REPO" commit -qm "drop a.sh"
git -C "$REPO" checkout -q -

# ------------------------------------------------------------------------------- 2. the fixtures
cat > "$WORK/mixed.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: the mixed case

**Files:** modify `a.sh`, `gone.sh`; create `new.sh`.

**Interfaces:** none.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/all-present.md" <<'PLAN'
## 🛠️ Implementation plan

### Task 1: everything still there

**Files:** modify `a.sh`; modify `dir with space/b.sh`.

- [ ] **Step 1:** do the thing.
PLAN

cat > "$WORK/no-tasks.md" <<'PLAN'
## Problem

There is no plan here at all — no `### Task` heading anywhere in the file.

**Files:** modify `a.sh`.
PLAN

# ------------------------------------------------------------------------------- 3. the verdicts
#
# run_case <label> <want-exit> <plan> [extra args…]
# stdout goes to a file; the assertions read that file. Nothing is piped through head/tail — the
# whole output is the evidence, and a truncated capture is how a wrong line goes unnoticed.
OUT="$WORK/out.txt"
run_case() {
  local label="$1" want="$2" plan="$3"; shift 3
  local got=0
  "$SCRIPT" -C "$REPO" "$@" "$plan" > "$OUT" 2>&1 || got=$?
  if [ "$got" != "$want" ]; then
    note_fail "$label — exit $got, wanted $want"
    sed 's/^/      /' "$OUT"
    return 0
  fi
  note_ok "$label"
}

want_line() {
  local label="$1" line="$2"
  if grep -Fxq "$line" "$OUT"; then
    note_ok "$label"
  else
    note_fail "$label — no line '$line' in the output:"
    sed 's/^/      /' "$OUT"
  fi
}

echo "== a plan with a stale modify path is exit 5, and says which path (#322) =="
run_case "C1 mixed plan exits 5             " 5 "$WORK/mixed.md"
want_line "C2 the present path is OK         " "OK modify a.sh (Task 1)"
want_line "C3 the absent path is MISSING     " "MISSING modify gone.sh (Task 1)"
want_line "C4 a create path is SKIPped       " "SKIP create new.sh (Task 1)"

echo "== a plan whose every path still exists is exit 0 =="
run_case "C5 all-present plan exits 0        " 0 "$WORK/all-present.md"
want_line "C6 a path with a space survives   " "OK modify dir with space/b.sh (Task 1)"

echo "== a file with no ### Task is a usage refusal (exit 2), not a silent pass =="
run_case "C7 task-less plan exits 2          " 2 "$WORK/no-tasks.md"

echo "== --base is READ, not merely accepted =="
run_case "C8 --base without-a finds a.sh gone" 5 "$WORK/all-present.md" --base without-a
want_line "C9 …and names it MISSING          " "MISSING modify a.sh (Task 1)"
run_case "C10 --base origin/main is the same as the default" 0 "$WORK/all-present.md" --base origin/main

# --------------------------------------------------- 4. the prose that has to CALL the script
#
# A shipped script nothing invokes is the same absence-shaped failure ci-wiring-check.py exists for,
# one layer up: `plan-freshness.sh` can be green on every case above while SKILL.md Step 2 never
# mentions it, and a run would then execute a stale plan exactly as it did before #322. So the
# call site is pinned too — per STEP, not per file, because a grep over the whole SKILL.md passes
# on a mention parked in any other step.

section() {  # section <file> <start-heading> <end-heading> -> path to the extracted block
  local file="$1" start="$2" end="$3" out="$WORK/section.txt"
  awk -v s="$start" -v e="$end" '
    index($0, s) == 1 { inside = 1 }
    inside && index($0, e) == 1 && index($0, s) != 1 { exit }
    inside { print }
  ' "$file" > "$out"
  printf '%s' "$out"
}

want_in() {  # want_in <label> <file> <needle>
  local label="$1" file="$2" needle="$3"
  if [ -s "$file" ] && grep -Fq -- "$needle" "$file"; then
    note_ok "$label"
  else
    note_fail "$label — '$needle' is not in $(basename "$file")"
  fi
}

[ -r "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

echo "== SKILL.md Step 2 must RUN the freshness pass and carry a STALE list (#322) =="
STEP2=$(section "$SKILL" "## Step 2 — " "## Step 3 — ")
want_in "P1 Step 2 calls plan-freshness.sh " "$STEP2" "plan-freshness.sh"
want_in "P2 Step 2 names the STALE list    " "$STEP2" "STALE:"
want_in "P3 Step 2 re-anchors via Interfaces" "$STEP2" "**Interfaces:**"

echo "== github-mechanics §2 must carry the call and the re-anchor recipe =="
[ -r "$MECHANICS" ] || { echo "FAIL: $MECHANICS missing"; exit 1; }
want_in "P4 §2 spells the freshness call   " "$MECHANICS" "plan-freshness.sh"
want_in "P5 §2 spells the re-anchor search " "$MECHANICS" "grep -n -l -F --"
want_in "P6 §2 names the STALE record        " "$MECHANICS" "STALE:"

echo "== Step 3 must explore ONCE and hand later sub-agents a pointer (#322) =="
STEP3=$(section "$SKILL" "## Step 3 — " "## Step 4 — ")
want_in "P7 Step 3 names the notes file    " "$STEP3" 'issue-$ISSUE-notes.md'
want_in "P8 Step 3 says pointer, not copy  " "$STEP3" "pointer"

echo "== Step 6's failing test must cross the seam the plan named (#310, #322) =="
STEP6=$(section "$SKILL" "## Step 6 — " "## Step 7 — ")
want_in "P9 Step 6 names the seam preamble " "$STEP6" "Seams under test"
want_in "P10 Step 6 links the seam doctrine" "$STEP6" "_shared/test-seams.md"

echo "== Step 7 must review on a SECOND axis, against the Spec (#322) =="
if [ -r "$SPEC_REVIEW" ]; then
  note_ok "P11 references/spec-review.md exists"
else
  note_fail "P11 references/spec-review.md exists — $SPEC_REVIEW is missing"
fi
STEP7=$(section "$SKILL" "## Step 7 — " "## Step 8 — ")
want_in "P12 Step 7 links the Spec brief   " "$STEP7" "](references/spec-review.md)"
want_in "P13 Step 7 routes creep to the PR " "$STEP7" "### Follow-ups"
want_in "P14 Step 7 refuses to rerank      " "$STEP7" "rerank"

# The credit is a licence obligation, not decoration: the brief, the a/b/c categories, the smell
# baseline and the two-heading aggregation are Matt Pocock's, taken under MIT.
want_in "P15 the brief credits its source  " "$SPEC_REVIEW" "mattpocock/skills"
want_in "P16 the brief carries the a/b/c   " "$SPEC_REVIEW" "scope creep"
want_in "P17 the brief bounds its length   " "$SPEC_REVIEW" "400 words"
# The Spec is fetched from an issue body — foreign text. A reference that ingests it and does not
# carry the boundary is the #266 failure one file over.
want_in "P18 the brief reads it as data    " "$SPEC_REVIEW" "untrusted-input-boundary.md"

[ "$FAILED" -eq 0 ] || exit 1
echo "plan-freshness golden test: all cases behaved as specified"
